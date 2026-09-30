import AppKit
import SwiftUI
import XCTest
import CoveCore
@testable import Cove

/// "Try on recent mail" and Notify, with injected Jev/Gmail responses and a recording notifier.
@MainActor final class CustomAgentBackfillTests: XCTestCase {
  let epoch = Date(timeIntervalSince1970: 2_000_000_000)

  func fixture(_ http: BackfillHTTP = BackfillHTTP()) throws -> (AppStore, Database, BackfillHTTP, RecordingNotifier) {
    let db = try Database(url: FileManager.default.temporaryDirectory.appendingPathComponent("CoveBackfill-" + UUID().uuidString + "/test.sqlite"))
    let store = try AppStore(database: db, accountEmail: "me@example.com", gmail: GmailClient(transport: http),
      gmailTokenProvider: { "test-token" }, syncClock: { self.epoch }, jev: JevClient(transport: http), jevKeyProvider: { "test-key" })
    let notifier = RecordingNotifier()
    store.agentNotifier = notifier
    store.agentsBypassKeyProtection = true
    return (store, db, http, notifier)
  }
  /// Subjects carry the fixture's verdict: MATCH, UNCLEAR, or anything else for no match.
  func mail(_ id: String, _ subject: String, hoursAgo: Double = 1, labels: Set<String> = ["INBOX"]) -> Mail {
    Mail(id: id, sender: "Acme", senderEmail: "billing@example.com", subject: subject,
         body: "Invoice #INV-2048. Amount due $1250 by July 15.", date: epoch.addingTimeInterval(-hoursAgo * 3600), labels: labels)
  }
  func mixedInbox() -> [Mail] {
    (0..<3).map { mail("m\($0)", "MATCH invoice \($0)", hoursAgo: Double($0 + 1)) }
      + (0..<2).map { mail("u\($0)", "UNCLEAR maybe \($0)", hoursAgo: Double($0 + 10)) }
      + (0..<4).map { mail("n\($0)", "Newsletter \($0)", hoursAgo: Double($0 + 20)) }
  }
  func previewReady(_ store: AppStore, _ agent: CustomAgent = .invoiceTemplate) async throws -> CustomAgentBackfillPreview {
    store.previewAgentBackfill(agent)
    await store.waitForAgentBackfill()
    let state = try XCTUnwrap(store.agentBackfill)
    XCTAssertEqual(state.phase, .ready, state.message ?? "")
    return state.preview
  }
  func modified(_ http: BackfillHTTP) async -> [String] {
    await http.requests.compactMap { request in
      guard request.url?.path.hasSuffix("/modify") == true else { return nil }
      return request.url?.pathComponents.dropLast().last
    }
  }

  func testPreviewChangesNothing() async throws {
    let (store, db, http, notifier) = try fixture()
    store.mails = mixedInbox()
    let before = store.mails
    let preview = try await previewReady(store)
    XCTAssertEqual(preview.summary, "Would label 3 · 2 unclear · 4 no match")
    XCTAssertEqual(preview.matches.map(\.mailID), ["m0", "m1", "m2"])
    XCTAssertEqual(store.mails, before)
    XCTAssertTrue(store.customAgents.runs.isEmpty)
    XCTAssertNil(try db.load(CustomAgentLibrary.self, key: "customAgents"))
    let requests = await http.requests
    XCTAssertEqual(requests.count, 9)
    XCTAssertTrue(requests.allSatisfy { $0.url?.host == "api.typesafe.ai" }, "Preview must not touch Gmail")
    XCTAssertTrue(notifier.posts.isEmpty)
  }

  func testApplyLabelsExactlyTheMatchesAndSendsUnclearToActivityOnly() async throws {
    let (store, _, http, notifier) = try fixture()
    store.mails = mixedInbox()
    var agent = CustomAgent.invoiceTemplate; agent.notifyOnMatch = true
    _ = try await previewReady(store, agent)
    store.applyAgentBackfill()
    await store.waitForAgentBackfill()
    let state = try XCTUnwrap(store.agentBackfill)
    XCTAssertEqual(state.phase, .done)
    XCTAssertEqual(state.result?.applied, 3); XCTAssertEqual(state.result?.failed, 0); XCTAssertEqual(state.result?.unclear, 2)
    let writes = await modified(http)
    XCTAssertEqual(Set(writes), ["m0", "m1", "m2"])
    for mail in store.mails {
      XCTAssertEqual(mail.labels.contains("Label_1"), mail.id.hasPrefix("m"), mail.id)
    }
    let runs = store.customAgents.runs
    XCTAssertEqual(Set(runs.filter { $0.appliedLabel == "Finance / Invoices" }.map(\.mailID)), ["m0", "m1", "m2"])
    let unclear = runs.filter { $0.decision?.outcome == .review }
    XCTAssertEqual(Set(unclear.map(\.mailID)), ["u0", "u1"])
    XCTAssertTrue(unclear.allSatisfy { $0.appliedLabel == nil && $0.completed })
    XCTAssertFalse(runs.contains { $0.mailID.hasPrefix("n") }, "No-match mail leaves Activity quiet")
    XCTAssertEqual(store.customAgents.agents.first?.status, .draft, "Apply keeps the agent's status")
    XCTAssertTrue(notifier.posts.isEmpty, "Backfill never notifies")
    let all = await http.requests
    XCTAssertFalse(all.contains { $0.url?.path.hasSuffix("/send") == true })
  }

  func testApplyPreparesRepliesWithoutSending() async throws {
    let (store, _, http, _) = try fixture()
    store.mails = [mail("m0", "MATCH invoice")]
    var agent = CustomAgent.invoiceTemplate
    agent.rules = [CustomAgentRule(condition: "MATCH", action: .draftReply, replyInstructions: "Acknowledge receipt.")]
    store.customAgentWriter = { _ in "Thanks, received." }
    let preview = try await previewReady(store, agent)
    XCTAssertEqual(preview.replyCount, 1); XCTAssertEqual(preview.labelCount, 0)
    store.applyAgentBackfill(); await store.waitForAgentBackfill()
    XCTAssertEqual(store.customAgents.runs.first?.replySuggestion, "Thanks, received.")
    XCTAssertEqual(store.mails[0].draft, "", "Replies wait in Activity")
    let gmail = await http.requests.filter { $0.url?.host == "gmail.googleapis.com" }
    XCTAssertTrue(gmail.isEmpty)
  }

  func testAlreadyLabeledMailIsSkipped() async throws {
    let (store, _, http, _) = try fixture()
    store.gmailLabels = [GmailLabel(id: "Label_1", name: "Finance / Invoices")]
    store.mails = [mail("m0", "MATCH one", labels: ["INBOX", "Label_1"]), mail("m1", "MATCH two")]
    _ = try await previewReady(store)
    store.applyAgentBackfill(); await store.waitForAgentBackfill()
    let writes = await modified(http)
    XCTAssertEqual(writes, ["m1"])
    XCTAssertEqual(store.agentBackfill?.result?.applied, 1)
    XCTAssertEqual(store.agentBackfill?.result?.alreadyLabeled, 1)
    // A second preview skips mail the agent already labeled, so it costs nothing again.
    let jevBefore = await http.requests.filter { $0.url?.host == "api.typesafe.ai" }.count
    store.agentEditor = nil
    let again = try await previewReady(store, try XCTUnwrap(store.customAgents.agents.first))
    XCTAssertFalse(again.items.contains { $0.mailID == "m1" })
    let jevAfter = await http.requests.filter { $0.url?.host == "api.typesafe.ai" }.count
    XCTAssertEqual(jevAfter - jevBefore, 1, "Only the never-applied m0 is checked again")
  }

  func testBoundOf200EmailsAndFourteenDays() async throws {
    let (store, _, http, _) = try fixture()
    let recent = (0..<250).map { mail("r\($0)", "Newsletter \($0)", hoursAgo: Double($0) * 0.5 + 0.1) }
    let old = (0..<5).map { mail("old\($0)", "MATCH old \($0)", hoursAgo: 24 * 15 + Double($0)) }
    let other = [mail("sent", "MATCH sent", labels: ["INBOX", "SENT"]), mail("arch", "MATCH archived", labels: []),
                 mail("trash", "MATCH trash", labels: ["INBOX", "TRASH"])]
    store.mails = old + other + recent
    let preview = try await previewReady(store)
    XCTAssertEqual(preview.items.count, 200)
    XCTAssertEqual(preview.items.first?.mailID, "r0", "Newest first")
    XCTAssertFalse(preview.items.contains { $0.mailID.hasPrefix("old") || ["sent", "arch", "trash"].contains($0.mailID) })
    let jev = await http.requests.filter { $0.url?.host == "api.typesafe.ai" }.count
    XCTAssertEqual(jev, 200)
    XCTAssertTrue(preview.matches.isEmpty)
  }

  func testCancellationStopsPreviewAndApply() async throws {
    let (store, _, http, _) = try fixture(BackfillHTTP(delay: true))
    store.mails = (0..<20).map { mail("m\($0)", "MATCH \($0)", hoursAgo: Double($0 + 1)) }
    store.previewAgentBackfill(.invoiceTemplate)
    while await http.requests.isEmpty { await Task.yield() }
    store.cancelAgentBackfill()
    await store.waitForAgentBackfill()
    XCTAssertNil(store.agentBackfill)
    let checked = await http.requests.count
    XCTAssertLessThanOrEqual(checked, CustomAgentBackfill.concurrency)
    try await Task.sleep(for: .milliseconds(300))
    let later = await http.requests.count
    XCTAssertEqual(later, checked, "No more requests after cancelling")
    XCTAssertTrue(store.customAgents.runs.isEmpty)

    // Apply can be cancelled too; counts stay exact.
    let fast = BackfillHTTP(delayModify: true)
    let (other, _, _, _) = try fixture(fast)
    other.mails = (0..<6).map { mail("m\($0)", "MATCH \($0)", hoursAgo: Double($0 + 1)) }
    _ = try await previewReady(other)
    other.applyAgentBackfill()
    while await modified(fast).isEmpty { await Task.yield() }
    other.cancelAgentBackfill()
    await other.waitForAgentBackfill()
    let result = try XCTUnwrap(other.agentBackfill?.result)
    XCTAssertEqual(result.stopped, "Cancelled")
    XCTAssertLessThan(result.applied, 6)
    XCTAssertEqual(other.mails.filter { $0.labels.contains("Label_1") }.count, result.applied)
  }

  func testNewMatchesNotifyAndNonMatchesDoNot() async throws {
    let (store, _, _, notifier) = try fixture()
    var agent = CustomAgent.invoiceTemplate; agent.notifyOnMatch = true
    XCTAssertTrue(store.saveCustomAgent(agent, status: .active))
    var fresh = mail("new", "MATCH June invoice"); fresh.date = epoch.addingTimeInterval(60)
    var quiet = mail("quiet", "Newsletter"); quiet.date = epoch.addingTimeInterval(120)
    var unclear = mail("maybe", "UNCLEAR"); unclear.date = epoch.addingTimeInterval(180)
    store.mails = [fresh, quiet, unclear, mail("history", "MATCH older invoice")]
    await store.runCustomAgents(); await store.runCustomAgents()
    XCTAssertEqual(notifier.posts.count, 1)
    let post = try XCTUnwrap(notifier.posts.first)
    XCTAssertEqual(post.title, "Financial agent")
    XCTAssertEqual(post.body, "Acme · MATCH June invoice")
    XCTAssertEqual(post.mailID, "new")
    XCTAssertFalse(post.body.contains("INV-2048"), "Never the email body")

    store.openNotifiedMail("new", account: "someone-else@example.com")
    XCTAssertNil(store.selectedID)
    store.openNotifiedMail("new", account: "me@example.com")
    XCTAssertEqual(store.selectedID, "new"); XCTAssertEqual(store.screen, "mail")
  }

  func testAgentWithoutNotifyStaysQuiet() async throws {
    let (store, _, _, notifier) = try fixture()
    XCTAssertTrue(store.saveCustomAgent(.invoiceTemplate, status: .active))
    var fresh = mail("new", "MATCH"); fresh.date = epoch.addingTimeInterval(60)
    store.mails = [fresh]
    await store.runCustomAgents()
    XCTAssertEqual(store.customAgents.runs.first?.appliedLabel, "Finance / Invoices")
    XCTAssertTrue(notifier.posts.isEmpty)
  }

  func testNotifySettingPersistsWithoutRestartingTheAgent() throws {
    let (store, db, _, _) = try fixture()
    XCTAssertTrue(store.saveCustomAgent(.invoiceTemplate, status: .active))
    var agent = try XCTUnwrap(store.customAgents.agents.first)
    let since = agent.activeSince
    agent.notifyOnMatch = true
    XCTAssertTrue(store.saveCustomAgent(agent, status: .active))
    XCTAssertEqual(store.customAgents.agents.first?.activeSince, since)
    XCTAssertEqual(try db.load(CustomAgentLibrary.self, key: "customAgents")?.agents.first?.notifies, true)
  }

  func testBackfillAndNotifyRender() async throws {
    _ = NSApplication.shared; DesignAssets.registerFonts()
    let (store, _, _, _) = try fixture()
    store.mails = mixedInbox()
    var agent = CustomAgent.invoiceTemplate; agent.notifyOnMatch = true
    _ = try await previewReady(store, agent)
    for width in [1180.0, 820.0] {
      store.agentEditor = agent
      let host = NSHostingView(rootView: CustomAgentEditor(store: store, agent: agent).foregroundStyle(Palette.ink))
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1500), styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = host
      for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-agent-editor-backfill-\(Int(width)).png"))
      window.contentView = nil; window.close()
    }
    XCTAssertTrue(store.customAgents.runs.isEmpty, "Rendering never applies")
  }
}

@MainActor final class RecordingNotifier: AgentNotifying {
  struct Post: Equatable { var title: String; var body: String; var mailID: String; var account: String }
  var posts: [Post] = []
  var status = AgentNotificationPermission.allowed
  var requests = 0
  func permission() async -> AgentNotificationPermission { status }
  func requestPermission() async -> AgentNotificationPermission { requests += 1; return status }
  func post(agentName: String, sender: String, subject: String, mailID: String, account: String) {
    posts.append(Post(title: agentName, body: Self.body(sender: sender, subject: subject), mailID: mailID, account: account))
  }
}

actor BackfillHTTP: HTTPTransport {
  var requests: [URLRequest] = []
  let delay: Bool
  let delayModify: Bool
  init(delay: Bool = false, delayModify: Bool = false) { self.delay = delay; self.delayModify = delayModify }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    var body: [String: Any] = [:]
    if request.url?.host == "api.typesafe.ai" {
      if delay { try await Task.sleep(for: .milliseconds(150)) }
      let text = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
      let json = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
      let subject = ((json?["state"] as? [String: Any])?["email"] as? [String: Any])?["subject"] as? String ?? text
      let choices = (((json?["questions"] as? [String: Any])?["classification"] as? [String: Any])?["criteria"] as? [String: Any]) ?? [:]
      let match = choices["rule_0"] != nil ? "rule_0" : "match"
      let choice = subject.contains("MATCH") && !subject.contains("UNCLEAR") ? match : subject.contains("UNCLEAR") ? "review" : "noMatch"
      body = ["model": "jev-fixture", "answers": ["classification": ["choice": choice, "confidence": 0.95], "evidence": ["choice": "0", "confidence": 0.9]]]
    } else if request.url?.path.hasSuffix("/labels") == true {
      body = request.httpMethod == "POST" ? ["id": "Label_1", "name": "Finance / Invoices", "type": "user"] : ["labels": []]
    } else if request.url?.path.hasSuffix("/modify") == true, delayModify {
      try await Task.sleep(for: .milliseconds(150))
    }
    return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
  }
}
