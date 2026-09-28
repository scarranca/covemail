import AppKit
import CoveCore
import CoreLocation
import SwiftUI
import XCTest
@testable import Cove

@MainActor final class HomeUpdateTests: XCTestCase {
  private var directories: [URL] = []
  override func tearDown() { directories.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }
  private func fixture(_ http: HomeUpdateHTTP = HomeUpdateHTTP()) throws -> (AppStore, Database, Mail) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    directories.append(dir)
    let db = try Database(url: dir.appendingPathComponent("mail.sqlite"))
    let mail = Mail(id: "message", sender: "Maya", senderEmail: "maya@example.com", subject: "Project update", body: "Review the project", decision: Decision(category: .work, confidence: 0.9, needsReply: 0.9, urgent: 0.8, model: "fixture"), isBulkOrAutomated: false)
    try db.saveMessage(mail)
    let store = try AppStore(database: db, accountEmail: "me@example.com", gmail: GmailClient(transport: http), gmailTokenProvider: { "fixture" }, syncClock: Date.init, calendarClient: GoogleCalendarClient(transport: http))
    store.screen = "mail"
    store.selectedID = mail.id
    return (store, db, mail)
  }
  private func event(_ status: String = "needsAction", offset: Double = 3600) -> LocalEvent {
    var event = LocalEvent(title: "Design review", start: Date().addingTimeInterval(offset), end: Date().addingTimeInterval(offset + 1800))
    event.id = "google-invite"; event.googleID = "invite"
    event.organizerName = "Alex Morgan"
    event.attendees = [CalendarAttendee(name: "Me", email: "me@example.com", response: status, isSelf: true)]
    return event
  }
  func testUndoWithinFiveSecondsDoesNotTouchGmailOrDisk() async throws {
    let http = HomeUpdateHTTP()
    let (store, db, mail) = try fixture(http)
    store.queueTrash(mail)
    XCTAssertTrue(store.visible.isEmpty)
    XCTAssertEqual(store.attentionCount, 0)
    XCTAssertEqual(store.trashDeadline!.timeIntervalSinceNow, 5, accuracy: 0.1)
    XCTAssertEqual(try db.loadMail().first?.labels, mail.labels)
    store.undoQueuedTrash()
    try await Task.sleep(for: .milliseconds(70))
    XCTAssertEqual(store.visible.map(\.id), [mail.id])
    XCTAssertEqual(store.selectedID, mail.id)
    let count = await http.requests.count
    XCTAssertEqual(count, 0)
  }
  func testCountdownCommitsOnceAndFailureRestoresVisibility() async throws {
    for status in [200, 503] {
      let http = HomeUpdateHTTP(status: status)
      let (store, _, mail) = try fixture(http)
      store.queueTrash(mail, delay: 0.03)
      store.queueTrash(mail, delay: 0.03)
      try await Task.sleep(for: .milliseconds(120))
      XCTAssertTrue(store.queuedTrashIDs.isEmpty)
      XCTAssertNil(store.trashDeadline)
      XCTAssertEqual(store.mails.first?.labels.contains("TRASH"), status == 200)
      XCTAssertEqual(store.visible.isEmpty, status == 200)
      XCTAssertEqual(store.error != nil, status != 200)
      let count = await http.requests.count
      XCTAssertEqual(count, 1)
    }
  }
  func testBatchUndoAndSignOutCancelAllPendingDeletes() async throws {
    let http = HomeUpdateHTTP()
    let (store, _, mail) = try fixture(http)
    var second = mail; second.id = "second"
    store.mails.append(second)
    store.queueTrash(mail, delay: 0.1)
    store.queueTrash(second, delay: 0.1)
    XCTAssertEqual(store.queuedTrashIDs.count, 2)
    store.undoQueuedTrash()
    XCTAssertEqual(store.visible.count, 2)
    store.queueTrash(mail, delay: 0.03)
    store.isSample = true
    store.disconnect()
    try await Task.sleep(for: .milliseconds(100))
    let count = await http.requests.count
    XCTAssertEqual(count, 0)
    XCTAssertTrue(store.queuedTrashIDs.isEmpty)
  }
  func testShortcutRespectsNativeEditorAndComposeFocus() throws {
    _ = NSApplication.shared
    let (store, _, _) = try fixture()
    let view = MailDeleteShortcut.ShortcutView(store: store)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view
    defer { store.undoQueuedTrash(); window.close() }
    let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
    let editor = NSTextView(frame: view.bounds)
    view.addSubview(editor); window.makeFirstResponder(editor)
    XCTAssertNotNil(view.handle(key)); XCTAssertTrue(store.queuedTrashIDs.isEmpty)
    window.makeFirstResponder(nil)
    store.showComposer = true
    XCTAssertNotNil(view.handle(key)); XCTAssertTrue(store.queuedTrashIDs.isEmpty)
    store.showComposer = false
    store.busy = true // Sync/AI activity must not silently disable the shortcut.
    XCTAssertNil(view.handle(key)); XCTAssertEqual(store.queuedTrashIDs, ["message"])
  }
  func testDeleteTargetsHoveredSwiftUIRowWithoutChangingOtherSelection() async throws {
    _ = NSApplication.shared
    let (store, _, first) = try fixture()
    store.isSample = true; store.priorityOnly = false
    var second = first; second.id = "hovered"; second.subject = "Hovered message"
    store.mails.append(second)
    let host = NSHostingView(rootView: HStack(spacing: 0) {
      VStack(spacing: 0) {
        MailListRow(store: store, mail: first)
        MailListRow(store: store, mail: second)
        Spacer()
      }.frame(width: 300)
      Color.white.frame(width: 100)
    }.frame(width: 400, height: 400))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    let shortcut = MailDeleteShortcut.ShortcutView(store: store); host.addSubview(shortcut)
    defer { store.undoQueuedTrash(); window.close() }
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    func targets(_ view: NSView) -> [MailRowPointerTarget.TargetView] {
      (view as? MailRowPointerTarget.TargetView).map { [$0] } ?? view.subviews.flatMap { targets($0) }
    }
    let row = try XCTUnwrap(targets(host).first { $0.mailID == second.id })
    XCTAssertGreaterThan(row.bounds.width, 250); XCTAssertGreaterThan(row.bounds.height, 20)
    let pointer = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
    XCTAssertEqual(MailRowPointerTarget.mailID(at: pointer, in: window), second.id)
    let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51))
    XCTAssertNil(shortcut.handle(key, pointerLocation: pointer))
    XCTAssertEqual(store.queuedTrashIDs, [second.id]); XCTAssertEqual(store.selectedID, first.id)
    // Until SwiftUI removes the queued row, another press must not delete the selected email.
    _ = shortcut.handle(key, pointerLocation: pointer)
    XCTAssertEqual(store.queuedTrashIDs, [second.id])
    store.undoQueuedTrash(); store.selectedID = nil
    XCTAssertNil(shortcut.handle(key, pointerLocation: pointer))
    XCTAssertEqual(store.queuedTrashIDs, [second.id]); XCTAssertNil(store.selectedID)
    store.undoQueuedTrash(); store.selectedID = first.id
    XCTAssertTrue(store.queuedTrashIDs.isEmpty)
    XCTAssertEqual(store.selected?.id, first.id)
    XCTAssertNil(MailRowPointerTarget.mailID(at: NSPoint(x: 390, y: 200), in: window), "Row \(row.frame), bounds \(row.bounds), in window \(row.convert(row.bounds, to: nil)), host \(host.bounds)")
    XCTAssertNil(shortcut.handle(key, pointerLocation: NSPoint(x: 390, y: 200)))
    XCTAssertEqual(store.queuedTrashIDs, [first.id])
    XCTAssertFalse(window.isVisible)
  }
  func testPointerTargetExcludesHiddenAndClippedRowsAndTracksReflow() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
    let row = MailRowPointerTarget.TargetView(mailID: "old")
    row.frame = NSRect(x: 0, y: 0, width: 300, height: 80)
    document.addSubview(row); scroll.documentView = document; window.contentView = scroll
    let point = row.convert(NSPoint(x: 20, y: 20), to: nil)
    XCTAssertEqual(MailRowPointerTarget.mailID(at: point, in: window), "old")
    row.mailID = "new"
    XCTAssertEqual(MailRowPointerTarget.mailID(at: point, in: window), "new")
    row.isHidden = true
    XCTAssertNil(MailRowPointerTarget.mailID(at: point, in: window))
    row.isHidden = false
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
    let clippedPoint = row.convert(NSPoint(x: 20, y: 20), to: nil)
    XCTAssertNil(MailRowPointerTarget.mailID(at: clippedPoint, in: window))
    XCTAssertNil(row.hitTest(NSPoint(x: 20, y: 20)))
  }
  func testBusyQueueRemainsUndoableAfterCountdownAndTimesOutCleanly() async throws {
    let http = HomeUpdateHTTP(); let (store, _, mail) = try fixture(http)
    store.busy = true
    store.queueTrash(mail, delay: 0.01, waitTimeout: 1)
    try await Task.sleep(for: .milliseconds(40))
    XCTAssertFalse(store.trashCommitting); XCTAssertTrue(store.canUndoTrash)
    store.undoQueuedTrash()
    XCTAssertEqual(store.visible.map(\.id), [mail.id])
    store.queueTrash(mail, delay: 0.01, waitTimeout: 0.03)
    try await Task.sleep(for: .milliseconds(140))
    XCTAssertTrue(store.queuedTrashIDs.isEmpty); XCTAssertNil(store.trashDeadline)
    XCTAssertFalse(store.trashCommitting); XCTAssertNotNil(store.error)
    XCTAssertFalse(store.mails[0].labels.contains("TRASH"))
    let count = await http.requests.count; XCTAssertEqual(count, 0)
  }
  func testDeletingAgainDuringCommitKeepsIndependentUndoAndNoDuplicateWrites() async throws {
    for undoSecond in [true, false] {
      let http = HomeUpdateHTTP(delay: .milliseconds(150)); let (store, _, first) = try fixture(http)
      var second = first; second.id = "second"; store.mails.append(second)
      store.queueTrash(first, delay: 0.01)
      try await Task.sleep(for: .milliseconds(50))
      XCTAssertTrue(store.trashCommitting)
      store.queueTrash(second, delay: 0.03)
      XCTAssertEqual(store.pendingTrashIDs, [second.id]); XCTAssertTrue(store.canUndoTrash)
      if undoSecond { store.undoQueuedTrash() }
      try await Task.sleep(for: .milliseconds(380))
      XCTAssertTrue(store.queuedTrashIDs.isEmpty); XCTAssertFalse(store.trashCommitting)
      XCTAssertNil(store.trashDeadline)
      XCTAssertTrue(store.mails[0].labels.contains("TRASH"))
      XCTAssertEqual(store.mails[1].labels.contains("TRASH"), !undoSecond)
      let requests = await http.requests
      XCTAssertEqual(requests.count, undoSecond ? 1 : 2)
    }
  }
  func testPendingReadAndBusyWorkDoNotSilentlyDropDeletion() async throws {
    let http = HomeUpdateHTTP(delay: .milliseconds(100)); let (store, _, mail) = try fixture(http)
    let reading = Task { await store.markViewed(mail) }
    try await Task.sleep(for: .milliseconds(20))
    store.queueTrash(mail, delay: 0.01)
    store.busy = true
    await reading.value
    XCTAssertFalse(store.trashCommitting); XCTAssertTrue(store.canUndoTrash)
    store.busy = false
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertTrue(store.mails[0].labels.contains("TRASH")); XCTAssertTrue(store.queuedTrashIDs.isEmpty)
    let requests = await http.requests
    XCTAssertEqual(requests.filter { $0.url!.path.hasSuffix("/trash") }.count, 1)
  }
  func testPendingInvitationFilterAndSampleResponsePersist() async throws {
    let (store, db, _) = try fixture()
    store.isSample = true
    let pending = event()
    var accepted = event("accepted"); accepted.id = "accepted"
    var expired = event(offset: -7200); expired.id = "expired"
    var other = event(); other.id = "other"; other.attendees?[0].isSelf = false
    store.events = [pending, accepted, expired, other]
    XCTAssertEqual(store.pendingInvitations.map(\.id), [pending.id])
    await store.respondToInvitation(pending, response: .tentative)
    XCTAssertTrue(store.pendingInvitations.isEmpty)
    XCTAssertEqual(try db.load([LocalEvent].self, key: "events")?.first(where: { $0.id == pending.id })?.ownResponse, "tentative")
    XCTAssertTrue(store.invitationNotice?.contains("Maybe") == true)
    await store.respondToInvitation(pending, response: .declined)
    XCTAssertFalse(store.todayEvents.contains(where: { $0.id == pending.id }))
  }
  func testFailedRSVPLeavesInvitationPendingWithVisibleReason() async throws {
    let (store, _, _) = try fixture(HomeUpdateHTTP(status: 403))
    store.calendarConnected = true
    let pending = event(); store.events = [pending]
    await store.respondToInvitation(pending, response: .accepted)
    XCTAssertEqual(store.pendingInvitations.count, 1)
    XCTAssertNotNil(store.invitationError)
    XCTAssertFalse(store.busy)
    XCTAssertNil(store.respondingEventID)
  }
  func testWeatherDenialIsVisibleAndDisablingDuringLocationPreventsFetch() async throws {
    let suite = "Cove-Weather-Test-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let http = HomeUpdateHTTP()
    let denied = HomeWeatherController(defaults: defaults, client: HomeWeatherClient(transport: http), locationProvider: {
      throw CoveError.message("Location access is off. Enter a city.")
    })
    await denied.refresh(useLocation: true)
    XCTAssertTrue(denied.error?.contains("Location access is off") == true)
    XCTAssertFalse(denied.enabled)
    XCTAssertFalse(denied.working)
    let weather = HomeWeatherController(defaults: defaults, client: HomeWeatherClient(transport: http), locationProvider: {
      try await Task.sleep(for: .milliseconds(30))
      return CLLocation(latitude: 59.913456, longitude: 10.753456)
    })
    let operation = Task { await weather.refresh(useLocation: true) }
    await Task.yield()
    weather.turnOff()
    await operation.value
    XCTAssertFalse(weather.enabled)
    XCTAssertNil(weather.cache)
    let count = await http.requests.count
    XCTAssertEqual(count, 0)
  }
  func testHomeAndUndoToastRenderAtTwoWidths() async throws {
    _ = NSApplication.shared
    DesignAssets.registerFonts()
    let (store, _, mail) = try fixture()
    var visible = mail
    visible.id = "visible-priority"
    visible.subject = "Website launch — final review"
    visible.body = "Could you review the staging site and send your sign-off before 3 PM?"
    store.mails.append(visible)
    store.isSample = true
    let day = Calendar.current.startOfDay(for: Date())
    store.now = day.addingTimeInterval(9 * 3600)
    var pending = event(); pending.start = day.addingTimeInterval(10 * 3600); pending.end = pending.start.addingTimeInterval(1800)
    store.events = [pending]
    for width in [720.0, 1100.0] {
      let host = NSHostingView(rootView: AgentHubView(store: store, loadLiveData: false)
        .overlay(alignment: .bottom) { MailDeletionToast(store: store).padding(20) })
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 950), styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = host
      for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
      store.queueTrash(mail)
      host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(250))
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-home-0118-\(Int(width)).png"))
      store.undoQueuedTrash(); window.close()
    }
  }
}
private actor HomeUpdateHTTP: HTTPTransport {
  let status: Int
  let delay: Duration
  private(set) var requests: [URLRequest] = []
  init(status: Int = 200, delay: Duration = .zero) { self.status = status; self.delay = delay }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    try await Task.sleep(for: delay)
    return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
}
