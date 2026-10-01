import AppKit
import CoveCore
import SwiftUI
import XCTest
@testable import Cove

@MainActor final class HubActionsTests: XCTestCase {
  private var directories: [URL] = []
  override func tearDown() {
    directories.forEach { try? FileManager.default.removeItem(at: $0) }
    super.tearDown()
  }
  private func fixture(_ http: HubActionsHTTP = HubActionsHTTP()) throws -> (AppStore, Database, Mail) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    directories.append(dir)
    let db = try Database(url: dir.appendingPathComponent("mail.sqlite"))
    let mail = Mail(id: "hub-email", sender: "Maya Chen", senderEmail: "maya@example.com", subject: "A quick catch-up next week?", body: "Would you like to catch up next week?", date: Date().addingTimeInterval(-86400),
      decision: Decision(category: .people, confidence: 0.95, needsReply: 0.85, urgent: 0.2, excerpt: "Would you like to catch up next week?", model: "Fixture"), isBulkOrAutomated: false)
    try db.saveMessage(mail)
    return (try store(db, http), db, mail)
  }
  private func store(_ db: Database, _ http: HubActionsHTTP) throws -> AppStore {
    try AppStore(database: db, accountEmail: "me@example.com", gmail: GmailClient(transport: http), gmailTokenProvider: { "fixture" }, syncClock: Date.init)
  }
  private func candidates(_ store: AppStore) -> [Mail] {
    KeepInTouch.candidates(mails: store.mails, accountEmail: store.accountEmail, now: Date(), ignored: store.ignoredKeepInTouch)
  }

  func testIgnorePersistsAcrossReloadAndNewMailAndCanBeRestored() throws {
    let (app, db, mail) = try fixture()
    XCTAssertEqual(candidates(app).count, 1)
    XCTAssertTrue(app.setKeepInTouchIgnored(" MAYA@EXAMPLE.COM ", ignored: true))
    XCTAssertTrue(candidates(app).isEmpty)
    let reopened = try store(db, HubActionsHTTP())
    XCTAssertEqual(reopened.ignoredKeepInTouch, ["maya@example.com"])
    var newer = mail; newer.id = "newer"; newer.date = Date().addingTimeInterval(-10)
    reopened.mails.append(newer)
    XCTAssertTrue(candidates(reopened).isEmpty)
    XCTAssertTrue(reopened.setKeepInTouchIgnored(mail.senderEmail, ignored: false))
    XCTAssertEqual(candidates(reopened).map(\.id), ["newer"])
    XCTAssertTrue(try store(db, HubActionsHTTP()).ignoredKeepInTouch.isEmpty)
    XCTAssertEqual(try db.loadMail(), [mail], "Ignoring a person must not modify mail")
  }

  func testIgnoreIsPerMailboxAndOldPreferencesStillDecode() throws {
    let (first, _, _) = try fixture()
    let (second, _, _) = try fixture()
    first.setKeepInTouchIgnored("maya@example.com", ignored: true)
    XCTAssertTrue(second.ignoredKeepInTouch.isEmpty)
    let encoded = try JSONEncoder().encode(Preferences())
    var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    old.removeValue(forKey: "ignoredKeepInTouch")
    let decoded = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: old))
    XCTAssertNil(decoded.ignoredKeepInTouch)
    XCTAssertFalse(first.setKeepInTouchIgnored("not-an-address", ignored: true))
    XCTAssertEqual(first.ignoredKeepInTouch, ["maya@example.com"])
  }

  func testArchiveRemovesOnlyInboxAndPersistsAfterGmailSuccess() async throws {
    let http = HubActionsHTTP()
    let (app, db, mail) = try fixture(http)
    app.selectedID = mail.id
    await app.archive(mail)
    let requests = await http.requests
    XCTAssertEqual(requests.count, 1)
    XCTAssertTrue(requests[0].url!.path.hasSuffix("/messages/hub-email/modify"))
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[0].httpBody)) as? [String: [String]])
    XCTAssertEqual(body["removeLabelIds"], ["INBOX"])
    XCTAssertEqual(body["addLabelIds"], [])
    let saved = try XCTUnwrap(db.loadMail().first)
    XCTAssertEqual(saved.labels, ["UNREAD"])
    XCTAssertEqual(saved.body, mail.body)
    XCTAssertNil(app.selectedID)
    app.chooseFolder("Archive")
    XCTAssertEqual(app.visible.map(\.id), [mail.id])
  }

  func testDeleteUsesTrashInsteadOfPermanentDelete() async throws {
    let http = HubActionsHTTP()
    let (app, db, mail) = try fixture(http)
    await app.trash(mail)
    let requests = await http.requests
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests[0].httpMethod, "POST")
    XCTAssertTrue(requests[0].url!.path.hasSuffix("/messages/hub-email/trash"))
    XCTAssertTrue(try XCTUnwrap(db.loadMail().first).labels.contains("TRASH"))
    XCTAssertTrue(app.visible.isEmpty)
    XCTAssertTrue(candidates(app).isEmpty)
    await app.trash(mail)
    let repeated = await http.requests.count
    XCTAssertEqual(repeated, 1)
  }

  func testFailedArchiveAndTrashKeepEmailVisible() async throws {
    for trash in [false, true] {
      let http = HubActionsHTTP(status: 503)
      let (app, db, mail) = try fixture(http)
      if trash { await app.trash(mail) } else { await app.archive(mail) }
      XCTAssertEqual(app.mails.first?.labels, mail.labels)
      XCTAssertEqual(try db.loadMail().first?.labels, mail.labels)
      XCTAssertNotNil(app.error)
      XCTAssertEqual(app.visible.count, 1)
    }
  }

  func testArchiveWorksDuringSyncAndSampleMutationsStayLocal() async throws {
    // Since 0.1.55 a running sync no longer blocks the user: archiving applies and reaches Gmail.
    let http = HubActionsHTTP()
    let (app, _, mail) = try fixture(http)
    app.syncing = true
    await app.archive(mail)
    XCTAssertFalse(app.mails.first?.labels.contains("INBOX") ?? true)
    let sent = await http.requests.count
    XCTAssertEqual(sent, 1)

    // The sample mailbox never contacts Gmail.
    let sampleHTTP = HubActionsHTTP()
    let (sample, db, sampleMail) = try fixture(sampleHTTP)
    sample.isSample = true
    await sample.archive(sampleMail)
    await sample.trash(sampleMail)
    let count = await sampleHTTP.requests.count
    XCTAssertEqual(count, 0)
    XCTAssertTrue(try XCTUnwrap(db.loadMail().first).labels.contains("TRASH"))
  }

  func testTrashCompletionCannotMutateAnotherMailbox() async throws {
    let started = expectation(description: "trash request")
    let http = HubActionsHTTP(started: started)
    let (app, db, mail) = try fixture(http)
    let operation = Task { await app.trash(mail) }
    await fulfillment(of: [started], timeout: 2)
    // Normal UI blocks sign-out while busy; exercise a forced lifecycle change too.
    app.busy = false
    app.isSample = true
    app.disconnect()
    app.mails = [mail]
    await http.release()
    await operation.value
    XCTAssertEqual(app.mails.first?.labels, mail.labels)
    XCTAssertEqual(try db.loadMail().first?.labels, mail.labels)
  }

  func testHubRendersIgnoreAndDirectMailActions() async throws {
    _ = NSApplication.shared
    let (app, _, _) = try fixture()
    let host = NSHostingView(rootView: AgentHubView(store: app, loadLiveData: false))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-hub-actions.png"))
    XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 1100)
  }

}

private actor HubActionsHTTP: HTTPTransport {
  private(set) var requests: [URLRequest] = []
  let status: Int
  let started: XCTestExpectation?
  private var continuation: CheckedContinuation<Void, Never>?
  init(status: Int = 200, started: XCTestExpectation? = nil) { self.status = status; self.started = started }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture")
    XCTAssertEqual(request.httpMethod, "POST")
    if let started {
      await withCheckedContinuation { continuation in self.continuation = continuation; started.fulfill() }
    }
    return (Data("{}".utf8), try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil)))
  }
  func release() { continuation?.resume(); continuation = nil }
}
