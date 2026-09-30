import AppKit
import CoveCore
import SwiftUI
import XCTest
@testable import Cove

/// Jev answers "match" when the subject contains MATCH; Google Tasks echoes created tasks.
private actor TasksFlowHTTP: HTTPTransport {
  var jevCalls = 0
  var created: [[String: Any]] = []
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    var body: [String: Any] = [:]
    if request.url?.host == "api.typesafe.ai" {
      jevCalls += 1
      let json = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
      let subject = ((json?["state"] as? [String: Any])?["email"] as? [String: Any])?["subject"] as? String ?? ""
      body = ["model": "jev-fixture", "answers": ["classification": ["choice": subject.contains("MATCH") ? "match" : "noMatch", "confidence": 0.93],
                                                  "evidence": ["choice": "0", "confidence": 0.9]]]
    } else if request.url?.host == "tasks.googleapis.com" {
      let sent = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
      if request.httpMethod == "POST" { created.append(sent) }
      body = request.httpMethod == "GET" ? ["items": []]
        : ["id": "t\(created.count)", "title": sent["title"] ?? "", "notes": sent["notes"] ?? "", "status": "needsAction"]
    }
    return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}

@MainActor final class TasksFlowTests: XCTestCase {
  private var directory: URL!
  override func setUp() { directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
  override func tearDown() { try? FileManager.default.removeItem(at: directory) }

  func testJevChecksEligibleMailOnceAndApprovedTasksReachGoogleTasks() async throws {
    let http = TasksFlowHTTP()
    let db = try Database(url: directory.appendingPathComponent("mail.sqlite"))
    var promise = Mail(id: "sent-1", threadID: "18f2abc", sender: "me@example.com", senderEmail: "me@example.com", to: "millet@uisr.io",
                       subject: "Re: MATCH account", body: "Of course, I'll add this to your account.", labels: ["SENT"])
    promise.isBulkOrAutomated = false
    var promo = Mail(id: "promo", sender: "Shop", senderEmail: "deals@shop.example", subject: "MATCH 50% off", body: "Buy now", labels: ["INBOX"])
    promo.isBulkOrAutomated = true
    try db.saveMailSnapshot([promise, promo])
    let store = try AppStore(database: db, accountEmail: "me@example.com", gmail: GmailClient(transport: http),
      gmailTokenProvider: { "token" }, syncClock: { Date() }, jev: JevClient(transport: http), jevKeyProvider: { "key" })
    store.tasksClient = GoogleTasksClient(transport: http)
    store.tasksConnected = true

    await store.checkForTasks(promo)
    var calls = await http.jevCalls
    XCTAssertEqual(calls, 0, "Marketing never reaches Jev")
    XCTAssertNil(store.mails.first { $0.id == "promo" }?.taskCheck)

    store.lookForTasks(inSent: promise)
    XCTAssertEqual(store.postSend?.phase, .checking)
    for _ in 0..<50 where store.postSend?.phase == .checking { try await Task.sleep(for: .milliseconds(20)) }
    XCTAssertEqual(store.postSend?.phase, .found)
    let checked = try XCTUnwrap(store.mails.first { $0.id == "sent-1" })
    XCTAssertEqual(checked.taskCheck?.found, true)
    XCTAssertEqual(try db.loadMessages(ids: ["sent-1"]).first?.taskCheck?.found, true, "Saved, so it's never billed twice")
    await store.checkForTasks(checked)
    calls = await http.jevCalls
    XCTAssertEqual(calls, 1)

    var instruction = ""
    let suggestions = try await store.suggestTasks(for: checked) { prompt in
      instruction = prompt.user
      return #"{"tasks":[{"title":"Add the plan to Millet's account","due":null,"notes":""}]}"#
    }
    XCTAssertTrue(instruction.contains("SENT BY the user"))
    XCTAssertEqual(suggestions.map(\.title), ["Add the plan to Millet's account"])
    let createdBefore = await http.created
    XCTAssertTrue(createdBefore.isEmpty, "Suggesting never creates a task")

    let result = await store.addTasks(suggestions, from: checked)
    XCTAssertEqual(result.created.map(\.title), ["Add the plan to Millet's account"])
    XCTAssertTrue(result.failed.isEmpty)
    let created = await http.created
    XCTAssertTrue((created.first?["notes"] as? String)?.contains("https://mail.google.com/mail/u/0/#all/18f2abc") == true)
    XCTAssertEqual(store.mails.first { $0.id == "sent-1" }?.taskCheck?.createdTaskIDs, ["t1"])
    XCTAssertEqual(store.sourceMail(for: result.created[0])?.id, "sent-1")
  }

  func testToastAndTasksScreenRender() async throws {
    _ = NSApplication.shared
    let db = try Database(url: directory.appendingPathComponent("render.sqlite"))
    let store = try AppStore(database: db, accountEmail: "me@example.com", gmail: GmailClient(), gmailTokenProvider: { "t" }, syncClock: { Date() })
    store.postSend = PostSendTaskCheck(mailID: "x", phase: .found)
    try await render(PostSendTaskToast(store: store).frame(width: 620, height: 90), size: CGSize(width: 620, height: 90), name: "tasks-toast-found")
    store.postSend = PostSendTaskCheck(mailID: "x", phase: .checking)
    try await render(PostSendTaskToast(store: store).frame(width: 620, height: 90), size: CGSize(width: 620, height: 90), name: "tasks-toast-checking")
    store.tasksConnected = true
    store.googleTasks = [
      GoogleTask(id: "1", title: "Add the plan to Millet's account", notes: nil, due: "2026-10-02T00:00:00.000Z", status: "needsAction"),
      GoogleTask(id: "2", title: "Send Sebastián the Q3 report", notes: nil, due: nil, status: "needsAction"),
    ]
    try await render(TasksView(store: store), size: CGSize(width: 900, height: 420), name: "tasks-screen")
    let source = Mail(id: "m1", threadID: "18f2abc", sender: "Millet", senderEmail: "millet@uisr.io", subject: "Plan for our account",
                      body: "Could you add the new plan to our account this week? Thanks!", labels: ["INBOX"])
    store.mails = [source]
    let linked = GoogleTask(id: "3", title: "Add the plan to Millet's account",
      notes: "She asked on Sept 30\nFrom: Millet · Plan for our account\nhttps://mail.google.com/mail/u/0/#all/18f2abc",
      due: "2026-10-02T00:00:00.000Z", status: "needsAction", webViewLink: "https://tasks.google.com/task/3")
    store.googleTasks.append(linked)
    try await render(TaskDetailView(store: store, task: linked, close: {}), size: CGSize(width: 560, height: 560), name: "tasks-detail")
  }

  private func render<V: View>(_ view: V, size: CGSize, name: String) async throws {
    let host = NSHostingView(rootView: view.background(Palette.canvas))
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    defer { window.close() }
    for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    XCTAssertFalse(window.isVisible)
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-\(name).png"))
  }
}
