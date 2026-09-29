import AppKit
import SwiftUI
import XCTest
import CoveCore
@testable import Cove

@MainActor final class LabelMailboxTests: XCTestCase {
  private var roots: [URL] = []
  override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; super.tearDown() }
  private func fixture(_ transport: LabelHTTP = LabelHTTP()) throws -> (AppStore, Database) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CoveLabels-" + UUID().uuidString)
    roots.append(root)
    let db = try Database(url: root.appendingPathComponent("mail.sqlite"))
    return (try AppStore(database: db, accountEmail: "alex@example.com", gmail: GmailClient(transport: transport),
      gmailTokenProvider: { "fixture" }, syncClock: Date.init), db)
  }
  private var invoice: GmailLabel { .init(id: "Label_invoice", name: "Finance / Invoices") }
  private func mail(_ id: String, labels: Set<String>, date: Double = 1) -> Mail {
    Mail(id: id, sender: "Acme Studio", senderEmail: "billing@example.com", subject: "Invoice for June services", body: "Invoice 2048. Thanks for another month.", date: Date(timeIntervalSince1970: date), labels: labels)
  }
  func testLabelScopeIncludesArchivedAndExcludesTrashSpamAndQueuedDeletes() throws {
    let (store, _) = try fixture(); store.isSample = true; store.gmailLabels = [invoice]
    store.mails = [mail("inbox", labels: [invoice.id, "INBOX", "UNREAD"], date: 3), mail("archive", labels: [invoice.id], date: 2),
      mail("trash", labels: [invoice.id, "TRASH"]), mail("spam", labels: [invoice.id, "SPAM"]), mail("other", labels: ["INBOX"])]
    store.chooseLabel(invoice)
    XCTAssertEqual(store.folderTitle, "Invoices"); XCTAssertEqual(store.selectedGmailLabel?.parent, "Finance")
    XCTAssertEqual(store.visible.map(\.id), ["inbox", "archive"])
    store.labelUnreadOnly = true; XCTAssertEqual(store.visible.map(\.id), ["inbox"])
    store.labelUnreadOnly = false; store.labelOldestFirst = true
    XCTAssertEqual(store.visible.map(\.id), ["archive", "inbox"])
    store.search = "missing"; XCTAssertTrue(store.visible.isEmpty)
    store.search = ""; store.queueTrash(store.mails[1], delay: 600)
    defer { store.undoQueuedTrash() }
    XCTAssertEqual(store.visible.map(\.id), ["inbox"])
    store.chooseFolder("Inbox"); XCTAssertFalse(store.labelUnreadOnly); XCTAssertFalse(store.labelOldestFirst)
  }
  func testInboxUnreadFilterKeepsOpenMessageUntilSelectionMoves() async throws {
    let (store, _) = try fixture(); store.isSample = true
    store.mails = [mail("new", labels: ["INBOX", "UNREAD"], date: 4), mail("next", labels: ["INBOX", "UNREAD"], date: 3),
      mail("read", labels: ["INBOX"], date: 2), mail("archived", labels: ["UNREAD"], date: 1)]
    store.chooseFolder("Inbox")
    XCTAssertEqual(store.inboxUnreadCount, 2)
    store.labelUnreadOnly = true
    XCTAssertEqual(store.visible.map(\.id), ["new", "next"])
    store.select(store.mails[0]); await store.markViewed(store.mails[0])
    store.reconcileSelection()
    XCTAssertEqual(store.selectedID, "new")
    XCTAssertEqual(store.visible.map(\.id), ["new", "next"])
    XCTAssertEqual(store.inboxUnreadCount, 1)
    store.moveSelection(by: 1)
    XCTAssertEqual(store.selectedID, "next")
    XCTAssertEqual(store.visible.map(\.id), ["next"])
    store.chooseFolder("Sent"); XCTAssertFalse(store.labelUnreadOnly)
    store.labelUnreadOnly = true; store.chooseFolder("Archive")
    XCTAssertEqual(store.labelUnreadOnly, false)
  }
  func testCatalogAndLabelPagePersistWithoutAdvancingMainSyncCursor() async throws {
    let http = LabelHTTP(); let (store, db) = try fixture(http)
    store.nextPage = "mailbox-next"
    try db.save("history-100", key: "gmailHistoryID")
    try db.save("mailbox-next", key: "gmailNextPage")
    await store.refreshLabels()
    XCTAssertEqual(store.customMailLabels, [invoice])
    let cached = try XCTUnwrap(try db.load([GmailLabel].self, key: "gmailLabels"))
    XCTAssertEqual(cached.first?.id, invoice.id)
    store.chooseLabel(invoice); await store.loadLabelMail()
    XCTAssertEqual(store.visible.map(\.id), ["older-invoice"])
    XCTAssertEqual(store.labelNextPages[invoice.id], "label-next")
    await store.loadLabelMail(older: true)
    XCTAssertEqual(Set(store.visible.map(\.id)), ["older-invoice", "archived-invoice"])
    XCTAssertNil(store.labelNextPages[invoice.id])
    XCTAssertEqual(store.nextPage, "mailbox-next")
    XCTAssertEqual(try db.load(String.self, key: "gmailNextPage"), "mailbox-next")
    XCTAssertEqual(try db.load(String.self, key: "gmailHistoryID"), "history-100")
    let list = await http.requests.filter { $0.url?.lastPathComponent == "messages" }
    XCTAssertEqual(list.count, 2)
    XCTAssertTrue(list.allSatisfy { $0.labelQuery("labelIds") == invoice.id })
    XCTAssertNil(list.first?.labelQuery("pageToken")); XCTAssertEqual(list.last?.labelQuery("pageToken"), "label-next")
    let (other, _) = try fixture(); XCTAssertTrue(other.gmailLabels.isEmpty)
    let restored = try AppStore(database: db, accountEmail: "alex@example.com", gmail: GmailClient(), gmailTokenProvider: { "fixture" }, syncClock: Date.init)
    XCTAssertEqual(restored.customMailLabels, [invoice])
  }
  func testManualFlagsAndLabelsUseGmailAndKeepJevSignalsIndependent() async throws {
    let http = LabelHTTP(); let (store, db) = try fixture(http)
    store.gmailLabels = [invoice]
    var input = mail("manual", labels: ["INBOX"])
    input.decision = Decision(category: .work, confidence: 0.9, needsReply: 0.8, urgent: 0.9, model: "fixture")
    store.mails = [input]
    await store.toggleFlag(input)
    XCTAssertTrue(store.mails[0].isStarred)
    XCTAssertEqual(store.mails[0].jevFlags, [.needsAction, .timeSensitive])
    XCTAssertTrue(try db.loadMail()[0].isStarred)
    await store.setLabel(invoice, on: store.mails[0], applied: true)
    XCTAssertTrue(store.mails[0].labels.contains(invoice.id))
    await store.toggleFlag(store.mails[0])
    XCTAssertFalse(store.mails[0].isStarred)
    XCTAssertEqual(store.mails[0].decision, input.decision)
    await store.setLabel(invoice, on: store.mails[0], applied: false)
    XCTAssertFalse(store.mails[0].labels.contains(invoice.id))
    let writes = await http.requests.filter { $0.httpMethod == "POST" }
    XCTAssertEqual(writes.count, 4)
    let bodies = try writes.map { try JSONSerialization.jsonObject(with: $0.httpBody!) as! [String: [String]] }
    XCTAssertEqual(bodies[0]["addLabelIds"], ["STARRED"])
    XCTAssertEqual(bodies[2]["removeLabelIds"], ["STARRED"])
    XCTAssertFalse(writes.contains { $0.url!.path.contains("send") })
  }
  func testFailedRemoteFlagDoesNotClaimSuccessAndJevThresholdsAreHonest() async throws {
    let http = LabelHTTP(failWrites: true); let (store, _) = try fixture(http)
    var input = mail("manual", labels: ["INBOX"])
    input.decision = Decision(category: .other, confidence: 0.54, needsReply: 0.649, urgent: 0.65, model: "fixture")
    store.mails = [input]
    await store.toggleFlag(input)
    XCTAssertFalse(store.mails[0].isStarred); XCTAssertNotNil(store.error)
    XCTAssertEqual(input.jevFlags, [.timeSensitive, .reviewCategory])
    store.chooseFolder("jev:timeSensitive"); XCTAssertEqual(store.visible.count, 1)
    store.chooseFolder("jev:needsAction"); XCTAssertTrue(store.visible.isEmpty)
    store.chooseFolder("Flagged"); XCTAssertTrue(store.visible.isEmpty)
    XCTAssertTrue(mail("not-assessed", labels: []).jevFlags.isEmpty)
  }
  func testAgentProvenanceOnlyAppearsForLabelsStillOnTheMessage() throws {
    let (store, _) = try fixture(); var agent = CustomAgent.invoiceTemplate; agent.name = "Financial agent"
    let input = mail("invoice", labels: [invoice.id]); store.gmailLabels = [invoice]
    var run = CustomAgentRun(agent: agent, mail: input); run.appliedLabel = invoice.name
    store.customAgents.agents = [agent]; store.customAgents.runs = [run]
    XCTAssertEqual(store.labelAttribution(for: input), "Labeled by Financial agent")
    XCTAssertNil(store.labelAttribution(for: mail("invoice", labels: [])))
  }
  func testCategoriesUseOnlyConfiguredOrAppliedAgentLabels() throws {
    let (store, _) = try fixture()
    store.gmailLabels = [invoice, .init(id: "personal", name: "Personal Gmail label")]
    var input = mail("categorized", labels: [invoice.id])
    input.decision = Decision(category: .purchases, confidence: 0.9, needsReply: 0, urgent: 0, model: "fixture")
    store.mails = [input]
    XCTAssertTrue(store.agentMailCategories.isEmpty, "Neither a built-in assessment nor a Gmail label seeds an agent category")
    var agent = CustomAgent(); agent.name = "Finance"; agent.rules = [
      .init(condition: "US", action: .label, labelName: "Finance / Invoices"),
      .init(condition: "MX", action: .label, labelName: "MX expense"),
      .init(condition: "Reply", action: .draftReply, labelName: "Must not appear")]
    store.customAgents.agents = [agent]
    XCTAssertEqual(store.agentMailCategories.map(\.name), [invoice.name, "MX expense"])
    XCTAssertEqual(store.agentMailCategories.first?.label?.id, invoice.id)
    XCTAssertNil(store.agentMailCategories.last?.label)
    XCTAssertEqual(store.agentLabels(on: input), [invoice])
    var run = CustomAgentRun(agent: agent, mail: input); run.appliedLabel = "finance / invoices"
    store.customAgents.runs = [run]
    XCTAssertEqual(store.agentMailCategories.count, 2, "Case variants must not duplicate categories")
    store.chooseLabel(invoice)
    XCTAssertEqual(store.visible.map(\.id), [input.id])
    XCTAssertEqual(store.selectedLabelID, invoice.id)
  }
  func testLabelAndFlagViewsRenderWithoutForegroundWindows() async throws {
    _ = NSApplication.shared; DesignAssets.registerFonts()
    let (store, _) = try fixture(); store.isSample = true
    store.gmailLabels = [invoice, .init(id: "Label_long", name: "Company / Finance / A very long label that should fit within the reading pane")]
    for index in 0..<6 {
      var input = mail("sample-\(index)", labels: index < 2 ? [invoice.id, "INBOX", "UNREAD"] : [invoice.id], date: Double(6 - index))
      if index == 0 {
        input.labels.insert("STARRED")
        input.labels.insert("Label_long")
        input.decision = Decision(category: .purchases, confidence: 0.9, needsReply: 0.8, urgent: 0.75, model: "fixture")
      }
      store.mails.append(input)
    }
    var agent = CustomAgent.invoiceTemplate; agent.name = "Financial agent"
    var run = CustomAgentRun(agent: agent, mail: store.mails[0]); run.appliedLabel = invoice.name
    store.customAgents.agents = [agent]; store.customAgents.runs = [run]
    store.chooseLabel(invoice); store.selectedID = store.mails[0].id
    for mode in ["mail", "categories"] {
    store.screen = mode
    for width in [1040.0, 1440.0] {
      let content = HStack(spacing: 0) {
        Sidebar(store: store).frame(width: 224); Divider()
        if mode == "categories" { MailCategoriesView(store: store) } else { MailboxView(store: store) }
      }
        .foregroundStyle(Palette.ink).background(Palette.canvas)
      let host = NSHostingView(rootView: content)
      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 960), styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false; window.contentView = host
      for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
      XCTAssertFalse(window.isVisible)
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-\(mode)-view-\(Int(width)).png"))
      window.close()
    }
    }
  }
}
private actor LabelHTTP: HTTPTransport {
  var requests: [URLRequest] = []
  let failWrites: Bool
  init(failWrites: Bool = false) { self.failWrites = failWrites }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    let component = request.url!.lastPathComponent
    var status = 200
    let object: [String: Any]
    switch component {
    case "labels": object = ["labels": [["id": "Label_invoice", "name": "Finance / Invoices", "type": "user"]]]
    case "messages":
      if request.labelQuery("pageToken") == "label-next" { object = ["messages": [["id": "archived-invoice"]]] }
      else { object = ["messages": [["id": "older-invoice"]], "nextPageToken": "label-next"] }
    case "modify": status = failWrites ? 403 : 200; object = [:]
    default:
      object = ["id": component, "threadId": component, "labelIds": ["Label_invoice"], "internalDate": "1000",
        "payload": ["mimeType": "text/plain", "headers": [["name": "Subject", "value": "Invoice"]], "body": ["data": "SW52b2ljZQ"]]]
    }
    return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
}
private extension URLRequest {
  func labelQuery(_ name: String) -> String? { URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value }
}
