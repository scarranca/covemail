import AppKit
import CoveCore
import SwiftUI
import XCTest
@testable import Cove

@MainActor final class MailPaginationTests: XCTestCase {
  private var roots: [URL] = []
  override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }
  private func request(_ cursor: String = "page-1", folder: String = "Inbox") -> MailPageRequest {
    .init(account: "me@example.com", folder: folder, search: "", priorityOnly: false,
      unreadOnly: false, oldestFirst: false, cursor: cursor)
  }
  private func fixture(_ http: PaginationHTTP = PaginationHTTP()) throws -> (AppStore, Database, PaginationHTTP) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); roots.append(root)
    let db = try Database(url: root.appendingPathComponent("mail.sqlite"))
    let store = try AppStore(database: db, accountEmail: "me@example.com", gmail: GmailClient(transport: http),
      gmailTokenProvider: { "fixture" }, syncClock: Date.init)
    store.chooseFolder("Inbox")
    store.mails = (0..<60).map { i in Mail(id: "cached-\(i)", sender: "Maya", senderEmail: "maya@example.com",
      subject: "Project update \(i)", body: "Please review the project before Thursday.",
      date: Date().addingTimeInterval(Double(-i * 60)), labels: ["INBOX"]) }
    store.nextPage = "page-1"
    return (store, db, http)
  }
  func testLoaderGatesConcurrentRequestsAndRequiresExplicitRetryAfterFailure() async throws {
    let loader = MailPageLoader(); var count = 0
    for (end, allowed) in [(false, true), (true, false)] {
      await loader.load(request(), atEnd: end, allowed: allowed) { count += 1; return (true, true) }
    }
    XCTAssertEqual(count, 0)
    let operation = Task { await loader.load(request(), atEnd: true, allowed: true) {
      count += 1; try? await Task.sleep(for: .milliseconds(40)); return (false, false)
    } }
    await Task.yield()
    await loader.load(request(), atEnd: true, allowed: true) { count += 1; return (true, true) }
    await operation.value
    XCTAssertEqual(count, 1); XCTAssertEqual(loader.failed, request())
    loader.leftEnd()
    await loader.load(request(), atEnd: true, allowed: true) { count += 1; return (true, true) }
    XCTAssertEqual(count, 1, "Scrolling or busy-state changes must not retry failed pages forever")
    await loader.load(request(), atEnd: true, allowed: true, retry: true) { count += 1; return (true, true) }
    XCTAssertEqual(count, 2); XCTAssertNil(loader.failed)
    await loader.load(request(), atEnd: true, allowed: true) { count += 1; return (true, true) }
    XCTAssertEqual(count, 2, "Repeated geometry must not request the same successful page")
  }
  func testFilteredOutPagePausesUntilNewScrollButDoesNotBlockAnotherFolder() async {
    let loader = MailPageLoader(); var count = 0
    await loader.load(request(), atEnd: true, allowed: true) { count += 1; return (true, false) }
    await loader.load(request("page-2"), atEnd: true, allowed: true) { count += 1; return (true, true) }
    XCTAssertEqual(count, 1)
    loader.leftEnd()
    await loader.load(request("page-2"), atEnd: true, allowed: true) { count += 1; return (true, false) }
    await loader.load(request("label-1", folder: "label:finance"), atEnd: true, allowed: true) { count += 1; return (true, true) }
    XCTAssertEqual(count, 3)
  }
  func testPagesRouteToCurrentScopeAndNeverFallBackFromExhaustedLabelToMailbox() async throws {
    let (store, _, http) = try fixture()
    let originalSelection = store.mails[0].id; store.selectedID = originalSelection
    let loaded = await store.loadNextMailPage(try XCTUnwrap(store.nextMailPageRequest))
    XCTAssertEqual(loaded?.advanced, true); XCTAssertEqual(loaded?.addedVisibleMail, true)
    XCTAssertEqual(store.selectedID, originalSelection); XCTAssertNil(store.nextPage)
    store.nextPage = "main-older"
    store.chooseFolder("label:finance")
    XCTAssertNil(store.nextMailPageRequest)
    store.labelNextPages["finance"] = "finance-older"
    let expected = try XCTUnwrap(store.nextMailPageRequest)
    let labelResult = await store.loadNextMailPage(expected)
    XCTAssertEqual(labelResult?.advanced, true)
    XCTAssertEqual(store.nextPage, "main-older"); XCTAssertNil(store.labelNextPages["finance"])
    store.chooseFolder("Inbox")
    let stale = await store.loadNextMailPage(expected)
    XCTAssertNil(stale)
    let queries = await http.pages
    XCTAssertEqual(queries.count, 2)
    XCTAssertEqual(queries[0]["pageToken"], "page-1"); XCTAssertNil(queries[0]["labelIds"])
    XCTAssertEqual(queries[1]["pageToken"], "finance-older"); XCTAssertEqual(queries[1]["labelIds"], "finance")
  }
  func testMailboxLoadsOnlyAfterActualViewportReachesEnd() async throws {
    _ = NSApplication.shared; DesignAssets.registerFonts()
    let (store, _, http) = try fixture()
    let host = NSHostingView(rootView: MailboxView(store: store).foregroundStyle(Palette.ink))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    func settle() async throws { for _ in 0..<12 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) } }
    try await settle()
    let before = await http.pages.count
    XCTAssertEqual(before, 0, "Lazy row creation must not start loading offscreen pages")
    func scrollView(_ view: NSView) -> NSScrollView? {
      if let scroll = view as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > 2000 { return scroll }
      return view.subviews.lazy.compactMap { scrollView($0) }.first
    }
    let scroll = try XCTUnwrap(scrollView(host))
    for _ in 0..<20 {
      let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -600, wheel2: 0, wheel3: 0))
      scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(30))
    }
    try await settle()
    let after = await http.pages.count
    XCTAssertEqual(after, 1)
    XCTAssertNil(store.nextPage); XCTAssertTrue(store.mails.contains { $0.id == "older-message" })
    XCTAssertNil(store.selectedID); XCTAssertFalse(window.isVisible)
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-auto-pagination.png"))
  }
  func testTomorrowReminderPersistsAcrossDSTAndReturnsInboxMessageWhenDue() throws {
    let (store, db, _) = try fixture()
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 8)))
    let tomorrow = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 9)))
    let mail = store.mails[0]; store.now = today
    store.snoozeUntilTomorrowMorning(mail, from: today, calendar: calendar)
    XCTAssertEqual(store.mails[0].snoozedUntil, tomorrow)
    XCTAssertFalse(store.visible.contains { $0.id == mail.id })
    XCTAssertEqual(try db.loadMail().first { $0.id == mail.id }?.snoozedUntil, tomorrow)
    XCTAssertEqual(store.mails[0].labels, mail.labels)
    store.chooseFolder("Snoozed"); XCTAssertTrue(store.visible.contains { $0.id == mail.id })
    store.now = tomorrow
    XCTAssertFalse(store.visible.contains { $0.id == mail.id })
    store.chooseFolder("Inbox"); XCTAssertTrue(store.visible.contains { $0.id == mail.id })
  }
}

private actor PaginationHTTP: HTTPTransport {
  private(set) var pages: [[String: String]] = []
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let url = try XCTUnwrap(request.url)
    let result: [String: Any]
    if url.lastPathComponent == "messages" {
      let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
      pages.append(query)
      try await Task.sleep(for: .milliseconds(60))
      result = ["messages": [["id": "older-message"]]]
    } else if url.lastPathComponent == "older-message" {
      result = ["id": "older-message", "threadId": "older-thread", "internalDate": "1600000000000", "labelIds": ["INBOX", "finance"],
        "payload": ["headers": [["name": "Subject", "value": "Older project update"]]]]
    } else {
      XCTFail("Unexpected endpoint \(url.path)"); throw URLError(.badURL)
    }
    return (try JSONSerialization.data(withJSONObject: result), try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)))
  }
}
