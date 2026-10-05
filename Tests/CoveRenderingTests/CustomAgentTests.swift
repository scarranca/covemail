import AppKit
import CoreText
import SwiftUI
import XCTest
import CoveCore
@testable import Cove

@MainActor final class CustomAgentTests: XCTestCase {
  let epoch = Date(timeIntervalSince1970: 2_000_000_000)
  func fixture(_ http: AgentTestHTTP = AgentTestHTTP()) throws -> (AppStore, Database, AgentTestHTTP) {
    let db = try Database(url: FileManager.default.temporaryDirectory.appendingPathComponent("CoveAgents-" + UUID().uuidString + "/test.sqlite"))
    let store = try AppStore(database: db, accountEmail: "me@example.com", gmail: GmailClient(transport: http), gmailTokenProvider: { "test-token" }, syncClock: { self.epoch }, jev: JevClient(transport: http), jevKeyProvider: { "test-key" })
    return (store, db, http)
  }
  func mail(_ id: String = "new", offset: Double = 1, labels: Set<String> = ["INBOX"]) -> Mail {
    Mail(id: id, sender: "Acme", senderEmail: "billing@example.com", subject: "Invoice June", body: "Invoice #INV-2048. Amount due $1250 by July 15.", date: epoch.addingTimeInterval(offset), labels: labels)
  }
  func replyAgent(action: CustomAgentAction = .draftReply) -> CustomAgent {
    var agent = CustomAgent.invoiceTemplate
    agent.rules = [CustomAgentRule(condition: "Invoice received", action: action, labelName: "US EXPENSE", replyInstructions: "Acknowledge receipt and ask for a purchase order.")]
    return agent
  }
  func testReplySuggestionIsDurableAndNeverSendsOrOverwritesDraft() async throws {
    let (store, db, http) = try fixture(AgentTestHTTP(choice: "rule_0"))
    var input = mail(); input.draft = "My existing draft"
    input.attachments = [MailAttachment(id: "text", filename: "invoice.txt", mimeType: "text/plain", byteCount: 15, data: Data("PO is missing".utf8).base64EncodedString())]
    store.mails = [input]
    var calls = 0
    store.customAgentWriter = { prompt in
      calls += 1
      XCTAssertTrue(prompt.user.contains("purchase order"))
      XCTAssertTrue(prompt.emails.contains("INV-2048"))
      XCTAssertTrue(prompt.evidence.contains("PO is missing"))
      return "Thanks for the invoice. Could you send the purchase order?"
    }
    XCTAssertTrue(store.saveCustomAgent(replyAgent(), status: .active))
    await store.runCustomAgents(); await store.runCustomAgents()
    XCTAssertEqual(calls, 1)
    let run = try XCTUnwrap(store.customAgents.runs.first)
    XCTAssertTrue(run.completed); XCTAssertNotNil(run.replySuggestion)
    XCTAssertEqual(try db.load(CustomAgentLibrary.self, key: "customAgents")?.runs.first?.replySuggestion, run.replySuggestion)
    XCTAssertEqual(store.mails[0].draft, "My existing draft")
    store.applyCustomAgentReply(run)
    XCTAssertEqual(store.mails[0].draft, "My existing draft"); XCTAssertNotNil(store.agentFailure)
    store.mails[0].draft = ""
    store.applyCustomAgentReply(run)
    XCTAssertEqual(store.mails[0].draft, run.replySuggestion)
    XCTAssertEqual(store.selectedID, input.id)
    XCTAssertTrue(store.customAgents.runs[0].replyApplied == true)
    store.mails[0].draft = "An edit after approval"
    store.applyCustomAgentReply(run)
    XCTAssertEqual(store.mails[0].draft, "An edit after approval")
    let requests = await http.requests
    XCTAssertEqual(requests.count, 1, "Draft rules must not write to Gmail")
  }
  func testFailedWriterRetriesWithoutRepeatingJevOrCompletedLabel() async throws {
    let (store, db, http) = try fixture(AgentTestHTTP(choice: "rule_0"))
    store.mails = [mail()]
    store.customAgentWriter = { _ in throw CoveError.message("Writer unavailable") }
    XCTAssertTrue(store.saveCustomAgent(replyAgent(action: .labelAndDraft), status: .active))
    await store.runCustomAgents()
    XCTAssertEqual(store.customAgents.runs[0].appliedLabel, "US EXPENSE")
    XCTAssertEqual(store.customAgents.runs[0].error, "Writer unavailable")
    XCTAssertFalse(store.customAgents.runs[0].completed)
    let restored = try AppStore(database: db, accountEmail: "me@example.com", gmail: GmailClient(transport: http), gmailTokenProvider: { "test" }, syncClock: { self.epoch }, jev: JevClient(transport: http), jevKeyProvider: { "test" })
    restored.mails = store.mails
    restored.customAgentWriter = { _ in "Please send a purchase order." }
    await restored.runCustomAgents(ignoreCooldown: true)
    XCTAssertTrue(restored.customAgents.runs[0].completed)
    XCTAssertNil(restored.customAgents.runs[0].error)
    let requests = await http.requests
    XCTAssertEqual(requests.filter { $0.url?.host == "api.typesafe.ai" }.count, 1)
    XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/modify") == true }.count, 1)
    XCTAssertFalse(requests.contains { $0.url?.path.hasSuffix("/send") == true })
  }
  func testNoMatchAndUncertainRulesNeverCallWriter() async throws {
    for (choice, confidence) in [("noMatch", 0.98), ("review", 0.98), ("rule_0", 0.4)] {
      let (store, _, _) = try fixture(AgentTestHTTP(choice: choice, confidence: confidence))
      store.mails = [mail()]
      store.customAgentWriter = { _ in XCTFail("Uncertain match drafted a reply"); return "Unexpected" }
      XCTAssertTrue(store.saveCustomAgent(replyAgent(), status: .active))
      await store.runCustomAgents()
      XCTAssertNil(store.customAgents.runs.first?.replySuggestion)
    }
  }
  func testUncertainResultsStayInActivityWithoutGmailWrites() async throws {
    let (store, db, http) = try fixture(AgentTestHTTP(choice: "review", confidence: 0.98))
    store.mails = [mail()]
    XCTAssertTrue(store.saveCustomAgent(.invoiceTemplate, status: .active))
    await store.runCustomAgents()
    let run = try XCTUnwrap(store.customAgents.runs.first)
    XCTAssertTrue(run.completed); XCTAssertEqual(run.decision?.outcome, .review)
    XCTAssertNil(run.appliedLabel); XCTAssertNil(run.replySuggestion)
    XCTAssertEqual(try db.load(CustomAgentLibrary.self, key: "customAgents")?.runs.first?.decision?.outcome, .review)
    let requests = await http.requests
    XCTAssertEqual(requests.count, 1)
    XCTAssertTrue(requests.allSatisfy { $0.url?.host == "api.typesafe.ai" })
  }
  func testConfidentNonMatchWithUnreadableAttachmentDoesNotBecomeReview() async throws {
    let (store, _, _) = try fixture(AgentTestHTTP(choice: "noMatch", confidence: 0.98))
    var input = mail(); input.attachments = [MailAttachment(id: "png", filename: "logo.png", mimeType: "image/png", byteCount: 100)]
    let result = try await store.previewCustomAgent(.invoiceTemplate, mail: input, synthetic: true)
    XCTAssertEqual(result.outcome, .noMatch); XCTAssertNil(result.label(for: .invoiceTemplate))
    XCTAssertFalse(result.warnings.isEmpty)
  }
  func testPauseWhileWriterRunsDiscardsSuggestion() async throws {
    let (store, _, _) = try fixture(AgentTestHTTP(choice: "rule_0"))
    store.mails = [mail()]
    store.customAgentWriter = { _ in
      store.setCustomAgentStatus(store.customAgents.agents[0], .paused)
      return "Should be discarded"
    }
    XCTAssertTrue(store.saveCustomAgent(replyAgent(), status: .active))
    await store.runCustomAgents()
    XCTAssertNil(store.customAgents.runs.first?.replySuggestion)
  }
  func testDraftActivePauseDuplicateDeleteAndReload() throws {
    let (store, db, _) = try fixture()
    XCTAssertTrue(store.saveCustomAgent(.invoiceTemplate, status: .draft))
    let draft = try XCTUnwrap(store.customAgents.agents.first)
    XCTAssertNil(draft.activeSince)
    store.setCustomAgentStatus(draft, .active)
    let active = try XCTUnwrap(store.customAgents.agents.first)
    XCTAssertEqual(active.activeSince, epoch)
    store.setCustomAgentStatus(active, .paused)
    XCTAssertEqual(store.customAgents.agents.first?.status, .paused)
    store.duplicateCustomAgent(active)
    XCTAssertEqual(store.customAgents.agents.count, 2)
    XCTAssertEqual(store.customAgents.agents.last?.status, .draft)
    XCTAssertTrue(store.saveCustomAgent(try XCTUnwrap(store.agentEditor), status: .draft))
    XCTAssertNotEqual(store.customAgents.agents.first?.id, store.customAgents.agents.last?.id)
    let restored = try AppStore(database: db, accountEmail: "me@example.com", gmail: GmailClient(), gmailTokenProvider: { "test" }, syncClock: { self.epoch })
    XCTAssertEqual(restored.customAgents, store.customAgents)
    store.deleteCustomAgent(active)
    XCTAssertEqual(store.customAgents.agents.count, 1)
    XCTAssertEqual(try db.load(CustomAgentLibrary.self, key: "customAgents"), store.customAgents)
  }
  func testPreviewUsesRealInstructionsAndNeverWritesGmailOrSavesARun() async throws {
    let (store, db, http) = try fixture()
    let agent = CustomAgent.invoiceTemplate
    let result = try await store.previewCustomAgent(agent, mail: mail(), synthetic: true)
    XCTAssertEqual(result.outcome, .match)
    XCTAssertEqual(result.label(for: agent), "Finance / Invoices")
    XCTAssertTrue(store.customAgents.runs.isEmpty)
    XCTAssertNil(try db.load(CustomAgentLibrary.self, key: "customAgents"))
    let requests = await http.requests
    XCTAssertEqual(requests.count, 1)
    XCTAssertEqual(requests.first?.url?.host, "api.typesafe.ai")
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: Any])
    let questions = body["questions"] as! [String: [String: Any]]
    XCTAssertTrue((questions["classification"]?["instructions"] as? String)?.contains(agent.instructions) == true)
  }
  func testActiveAgentLabelsNewIncomingOnlyAndNeverReevaluatesCompletedMail() async throws {
    let (store, db, http) = try fixture()
    var decided = mail(); decided.decision = Decision(category: .work, confidence: 1, needsReply: 0, urgent: 0, model: "fixture")
    store.mails = [decided, mail("old", offset: -1), mail("sent", labels: ["INBOX", "SENT"]), mail("archived", labels: []), mail("local-draft"), mail("spam", labels: ["INBOX", "SPAM"])]
    XCTAssertTrue(store.saveCustomAgent(.invoiceTemplate, status: .active))
    await store.runCustomAgents(); await store.runCustomAgents()
    XCTAssertEqual(store.customAgents.runs.count, 1)
    XCTAssertEqual(store.customAgents.runs.first?.appliedLabel, "Finance / Invoices")
    XCTAssertTrue(store.mails[0].labels.contains("Label_1"))
    XCTAssertEqual(try db.loadMail().first?.labels, store.mails[0].labels)
    let requests = await http.requests
    XCTAssertEqual(requests.filter { $0.url?.host == "api.typesafe.ai" }.count, 1)
    let modify = requests.filter { $0.url?.path.hasSuffix("/modify") == true }
    XCTAssertEqual(modify.count, 1)
    let body = try JSONSerialization.jsonObject(with: modify[0].httpBody!) as! [String: [String]]
    XCTAssertEqual(body["addLabelIds"], ["Label_1"]); XCTAssertEqual(body["removeLabelIds"], [])
  }
  func testLowConfidenceUnsupportedAttachmentAndNoMatch() async throws {
    for (choice, confidence, outcome) in [("match", 0.5, CustomAgentOutcome.review), ("noMatch", 0.98, .noMatch), ("review", 0.99, .review)] {
      let http = AgentTestHTTP(choice: choice, confidence: confidence)
      let (store, _, _) = try fixture(http)
      let result = try await store.previewCustomAgent(.invoiceTemplate, mail: mail(), synthetic: true)
      XCTAssertEqual(result.outcome, outcome)
      if outcome == .review { XCTAssertNil(result.label(for: .invoiceTemplate)) }
      if outcome == .noMatch { XCTAssertNil(result.label(for: .invoiceTemplate)) }
    }
    let (store, _, _) = try fixture()
    var value = mail(); value.attachments = [MailAttachment(id: "png", filename: "scan.png", mimeType: "image/png", byteCount: 100)]
    let result = try await store.previewCustomAgent(.invoiceTemplate, mail: value, synthetic: true)
    XCTAssertEqual(result.outcome, .review)
    XCTAssertFalse(result.warnings.isEmpty)
  }
  func testLabelFailureRetriesSavedDecisionWithoutRepeatingJev() async throws {
    let http = AgentTestHTTP(failModify: true)
    let (store, db, _) = try fixture(http)
    store.mails = [mail()]
    XCTAssertTrue(store.saveCustomAgent(.invoiceTemplate, status: .active))
    await store.runCustomAgents()
    XCTAssertFalse(store.customAgents.runs[0].completed)
    XCTAssertNotNil(store.customAgents.runs[0].decision)
    XCTAssertNotNil(store.customAgents.runs[0].error)
    let restored = try AppStore(database: db, accountEmail: "me@example.com", gmail: GmailClient(transport: http), gmailTokenProvider: { "test" }, syncClock: { self.epoch }, jev: JevClient(transport: http), jevKeyProvider: { "test" })
    restored.mails = store.mails
    await restored.runCustomAgents()
    await http.setFailModify(false)
    await restored.runCustomAgents(ignoreCooldown: true)
    XCTAssertTrue(restored.customAgents.runs[0].completed)
    XCTAssertNil(restored.customAgents.runs[0].error)
    let requests = await http.requests
    XCTAssertEqual(requests.filter { $0.url?.host == "api.typesafe.ai" }.count, 1)
    XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/modify") == true }.count, 2)
  }
  func testPauseDuringEvaluationPreventsLabelWrites() async throws {
    let http = AgentTestHTTP(delay: true)
    let (store, _, _) = try fixture(http)
    store.mails = [mail()]; XCTAssertTrue(store.saveCustomAgent(.invoiceTemplate, status: .active))
    let task = Task { await store.runCustomAgents() }
    while await http.requests.isEmpty { await Task.yield() }
    store.setCustomAgentStatus(store.customAgents.agents[0], .paused)
    await task.value
    XCTAssertTrue(store.customAgents.runs.isEmpty)
    let requests = await http.requests
    XCTAssertFalse(requests.contains { $0.url?.host == "gmail.googleapis.com" })
  }
  func testEditingDuringEvaluationDiscardsOldDecisionAndDisconnectClearsLibrary() async throws {
    let http = AgentTestHTTP(delay: true)
    let (store, _, _) = try fixture(http)
    store.mails = [mail()]; XCTAssertTrue(store.saveCustomAgent(.invoiceTemplate, status: .active))
    let task = Task { await store.runCustomAgents() }
    while await http.requests.isEmpty { await Task.yield() }
    var updated = store.customAgents.agents[0]; updated.instructions = "Only newsletter subscriptions."
    XCTAssertTrue(store.saveCustomAgent(updated, status: .active))
    await task.value
    XCTAssertTrue(store.customAgents.runs.isEmpty)
    store.isSample = true; store.disconnect()
    XCTAssertTrue(store.customAgents.agents.isEmpty)
    let requests = await http.requests
    XCTAssertEqual(requests.count, 1)
  }
  func testNewMailSyncRunsCustomAgentsWithoutBuiltInOrganization() async throws {
    let (store, _, _) = try fixture()
    XCTAssertFalse(store.preferences.autoClassify)
    XCTAssertTrue(store.saveCustomAgent(.invoiceTemplate, status: .active))
    await store.sync()
    XCTAssertEqual(store.customAgents.runs.count, 1)
    XCTAssertEqual(store.customAgents.runs.first?.mailID, "new")
    XCTAssertTrue(store.customAgents.runs.first?.completed == true)
  }
  func testPDFTextIsReadAsEvidence() async throws {
    let (store, _, http) = try fixture()
    let bytes = NSMutableData()
    let consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
    var bounds = CGRect(x: 0, y: 0, width: 500, height: 300)
    let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &bounds, nil))
    context.beginPDFPage(nil)
    context.textPosition = CGPoint(x: 30, y: 150)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "PDF invoice INV-2048 amount due 1250", attributes: [.font: NSFont.systemFont(ofSize: 16)]))
    CTLineDraw(line, context); context.endPDFPage(); context.closePDF()
    var value = mail()
    value.attachments = [MailAttachment(id: "pdf", filename: "invoice.pdf", mimeType: "application/pdf", byteCount: bytes.length, data: (bytes as Data).base64EncodedString())]
    let answer = try await store.previewCustomAgent(.invoiceTemplate, mail: value, synthetic: true)
    XCTAssertTrue(answer.warnings.isEmpty)
    let requests = await http.requests
    XCTAssertTrue(String(data: requests[0].httpBody!, encoding: .utf8)!.contains("PDF invoice INV-2048"))
  }
  func testValidationAndSampleCannotEnable() throws {
    let (store, _, _) = try fixture()
    var agent = CustomAgent.invoiceTemplate
    agent.labelName = "TRASH"
    XCTAssertFalse(store.saveCustomAgent(agent, status: .active))
    XCTAssertNotNil(store.agentFailure)
    store.isSample = true
    XCTAssertFalse(store.saveCustomAgent(.invoiceTemplate, status: .active))
    XCTAssertTrue(store.saveCustomAgent(.invoiceTemplate, status: .draft))
  }
  func testReadableTextAttachmentIsIncludedAndLargeInputForcesReview() async throws {
    let (store, _, http) = try fixture()
    var value = mail()
    let data = Data("Invoice #attachment with amount due.".utf8)
    value.attachments = [MailAttachment(id: "txt", filename: "invoice.txt", mimeType: "text/plain", byteCount: data.count, data: data.base64EncodedString())]
    _ = try await store.previewCustomAgent(.invoiceTemplate, mail: value, synthetic: true)
    let requests = await http.requests
    XCTAssertTrue(String(data: requests[0].httpBody!, encoding: .utf8)!.contains("Invoice #attachment"))
    value.body = String(repeating: "A long invoice paragraph. ", count: 3000)
    let result = try await store.previewCustomAgent(.invoiceTemplate, mail: value, synthetic: true)
    XCTAssertEqual(result.outcome, .review)
  }
  func testConditionalAgentScreensRender() async throws {
    _ = NSApplication.shared; DesignAssets.registerFonts()
    let (store, _, _) = try fixture()
    var agent = replyAgent(action: .labelAndDraft)
    agent.name = "Fin"; agent.instructions = "Find transactions where our company is the buyer."
    agent.rules![0].condition = "The buyer is Happy Finances for All or Cherry"
    agent.rules!.append(CustomAgentRule(condition: "The buyer is Disruptive Learning or Gigstack", labelName: "MX expense"))
    for width in [720.0, 1100.0] {
      for activity in [false, true] {
        store.customAgents.agents = [agent]
        var run = CustomAgentRun(agent: agent, mail: mail())
        run.completed = true; run.matchedCondition = agent.rules![0].condition
        run.appliedLabel = "US EXPENSE"; run.replySuggestion = "Thanks for sending the invoice. Could you share the purchase order number so we can review it?"
        store.customAgents.runs = [run]
        store.agentEditor = activity ? nil : agent
        store.agentActivityID = activity ? agent.id : nil
        let host = NSHostingView(rootView: CustomAgentsView(store: store).foregroundStyle(Palette.ink))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 1350), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-conditional-\(activity ? "activity" : "editor")-\(Int(width)).png"))
        window.close()
      }
    }
  }
  func testAgentScreensRenderAtTwoWidths() async throws {
    _ = NSApplication.shared; DesignAssets.registerFonts()
    let (store, _, _) = try fixture()
    for status in CustomAgentStatus.allCases {
      var agent = CustomAgent.invoiceTemplate; agent.name = status == .active ? "Financial agent" : status == .paused ? "Newsletter organizer" : "Project updates"
      XCTAssertTrue(store.saveCustomAgent(agent, status: status))
    }
    for width in [720.0, 1100.0] {
      for editor in [false, true] {
        store.agentEditor = editor ? .invoiceTemplate : nil
        let host = NSHostingView(rootView: CustomAgentsView(store: store).foregroundStyle(Palette.ink))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 960), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(25)) }
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-agents-\(editor ? "create" : "list")-\(Int(width)).png"))
        window.close()
      }
    }
  }

  func testModelBrainUsesContextAppliesExtrasAndLearnsFromUndo() async throws {
    let (store, _, http) = try fixture()
    store.mails = [mail(labels: ["INBOX", "UNREAD"])]
    var prompts: [AIPrompt] = []
    store.agentBrainWriter = { prompt in
      prompts.append(prompt)
      return #"{"choice":"step_1","confidence":0.93,"why":"Acme sent invoice INV-2048 with an amount due.","quote":"Amount due $1250 by July 15."}"#
    }
    var agent = replyAgent(action: .label)
    agent.rules![0].extras = [.flag, .markRead]
    XCTAssertTrue(store.saveCustomAgent(agent, status: .active))
    await store.runCustomAgents()
    let run = try XCTUnwrap(store.customAgents.runs.first)
    XCTAssertEqual(run.decision?.reason, "Acme sent invoice INV-2048 with an amount due.")
    XCTAssertEqual(run.appliedLabel, "US EXPENSE")
    XCTAssertEqual(run.extrasApplied, [.flag, .markRead])
    XCTAssertTrue(store.mails[0].isStarred); XCTAssertFalse(store.mails[0].isUnread)
    let prompt = try XCTUnwrap(prompts.first)
    XCTAssertTrue(prompt.user.contains("step_1: Invoice received"))
    XCTAssertTrue(prompt.user.contains("Sender: Acme <billing@example.com>"))
    XCTAssertTrue(prompt.user.contains("untrusted evidence"))
    XCTAssertTrue(prompt.emails.contains("INV-2048"))
    let jevCalls = await http.requests.filter { $0.url?.host == "api.typesafe.ai" }.count
    XCTAssertEqual(jevCalls, 0, "with a writing model, Jev isn't asked")
    // "Wrong — undo" puts the email back and teaches the agent.
    await store.rejectAgentRun(run)
    let undone = try XCTUnwrap(store.customAgents.runs.first)
    XCTAssertEqual(undone.feedback, .wrong)
    XCTAssertNil(undone.extrasApplied)
    XCTAssertEqual(undone.decision?.outcome, .noMatch)
    XCTAssertFalse(store.mails[0].isStarred); XCTAssertTrue(store.mails[0].isUnread)
    XCTAssertEqual(store.customAgents.agents.first?.examples?.first?.verdict, "Not a match")
    // The next decision sees that verdict.
    store.mails.append(mail("second", offset: 5, labels: ["INBOX", "UNREAD"]))
    await store.runCustomAgents()
    XCTAssertTrue(try XCTUnwrap(prompts.last).user.contains("→ Not a match"))
  }

  func testUnsureEmailWaitsThenYesAppliesTheChosenStep() async throws {
    let (store, _, _) = try fixture()
    store.mails = [mail()]
    store.agentBrainWriter = { _ in #"{"choice":"step_1","confidence":0.55,"why":"Looks like an invoice but no amount is stated."}"# }
    var agent = replyAgent(action: .label)
    agent.rules!.append(CustomAgentRule(condition: "A receipt for something already paid", labelName: "Receipts"))
    XCTAssertTrue(store.saveCustomAgent(agent, status: .active))
    await store.runCustomAgents()
    let run = try XCTUnwrap(store.customAgents.runs.first)
    XCTAssertEqual(run.decision?.outcome, .review)
    XCTAssertNil(run.appliedLabel, "nothing changes in Gmail while unsure")
    let saved = try XCTUnwrap(store.customAgents.agents.first)
    await store.confirmAgentRun(run, ruleID: saved.rules![0].id)
    let confirmed = try XCTUnwrap(store.customAgents.runs.first)
    XCTAssertEqual(confirmed.feedback, .correct)
    XCTAssertEqual(confirmed.appliedLabel, "US EXPENSE")
    XCTAssertEqual(confirmed.decision?.outcome, .match)
    XCTAssertEqual(store.customAgents.agents.first?.examples?.first?.verdict, "Step 1: Invoice received")
  }

  func testRedesignedActivityRenders() async throws {
    _ = NSApplication.shared; DesignAssets.registerFonts()
    let (store, _, _) = try fixture()
    var agent = replyAgent(action: .labelAndDraft)
    agent.rules![0].extras = [.flag]
    XCTAssertTrue(store.saveCustomAgent(agent, status: .active))
    agent = try XCTUnwrap(store.customAgents.agents.first)
    let invoice = mail("a", offset: 10, labels: ["INBOX", "UNREAD"])
    var receipt = mail("b", offset: 5); receipt.subject = "Your receipt from Acme"; receipt.body = "Payment received, thank you."
    store.mails = [invoice, receipt] + Samples.mail
    var review = CustomAgentRun(agent: agent, mail: receipt); review.completed = true; review.sender = "Acme"
    review.decision = CustomAgentDecision(outcome: .review, confidence: 0.55, excerpt: "Payment received, thank you.", model: "Claude Sonnet", warnings: [],
                                          reason: "It mentions a payment, but it reads like a receipt rather than an invoice.")
    var match = CustomAgentRun(agent: agent, mail: invoice); match.completed = true; match.sender = "Acme"
    match.decision = CustomAgentDecision(outcome: .match, confidence: 0.94, excerpt: "Amount due $1250 by July 15.", model: "Claude Sonnet", warnings: [],
                                         ruleID: agent.rules![0].id, reason: "Acme sent invoice INV-2048 with $1,250 due July 15.")
    match.appliedLabel = "US EXPENSE"; match.extrasApplied = [.flag]
    match.replySuggestion = "Thanks for the invoice. Could you share the purchase order number?"
    store.customAgents.runs = [review, match]
    store.agentActivityID = agent.id
    let host = NSHostingView(rootView: CustomAgentsView(store: store).foregroundStyle(Palette.ink))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = host
    for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(30)) }
    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-agent-activity-v2-1280.png"))
    window.close()
  }

  func testJevGetsConversationSenderAboutYouAndVerdicts() async throws {
    let (store, _, http) = try fixture(AgentTestHTTP(choice: "rule_0"))
    var earlier = mail("earlier", offset: -86_400 * 3); earlier.threadID = "t1"; earlier.body = "We sent the June invoice last week."
    var current = mail("current", offset: 2, labels: ["INBOX", "UNREAD"]); current.threadID = "t1"
    store.mails = [earlier, current]
    store.preferences.personal = { var p = PersonalContext(); p.name = "Santiago"; p.company = "gigstack"; return p }()
    var agent = replyAgent(action: .label)
    agent.learn(CustomAgentExample(mail: earlier, verdict: "Step 1: Invoice received"))
    XCTAssertTrue(store.saveCustomAgent(agent, status: .active))
    var saved = try XCTUnwrap(store.customAgents.agents.first); saved.examples = agent.examples
    store.customAgents.agents = [saved]
    XCTAssertFalse(store.agentsUseModel, "with a TypeSafe key, Jev decides")
    await store.runCustomAgents()
    let requests = await http.requests
    let jevRequest = try XCTUnwrap(requests.first { $0.url?.host == "api.typesafe.ai" })
    let body = try XCTUnwrap(jevRequest.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
    let state = try XCTUnwrap(body["state"] as? [String: Any])
    XCTAssertTrue((state["sender"] as? String)?.contains("1 earlier emails from them") == true, "\(state["sender"] ?? "")")
    XCTAssertEqual((state["conversation"] as? [[String: Any]])?.first?["text"] as? String, "We sent the June invoice last week.")
    XCTAssertTrue((state["aboutUser"] as? String)?.contains("Santiago, gigstack") == true)
    XCTAssertEqual((state["userVerdicts"] as? [[String: Any]])?.first?["verdict"] as? String, "Step 1: Invoice received")
    XCTAssertEqual(store.customAgents.runs.first?.appliedLabel, "US EXPENSE")
  }
}

actor AgentTestHTTP: HTTPTransport {
  var requests: [URLRequest] = []
  let choice: String
  let confidence: Double
  var failModify: Bool
  let delay: Bool
  init(choice: String = "match", confidence: Double = 0.95, failModify: Bool = false, delay: Bool = false) {
    self.choice = choice; self.confidence = confidence; self.failModify = failModify; self.delay = delay
  }
  func setFailModify(_ value: Bool) { failModify = value }
  func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    var body: [String: Any] = [:]; var status = 200
    if request.url?.host == "api.typesafe.ai" {
      if delay { try await Task.sleep(for: .milliseconds(150)) }
      body = ["model": "jev-fixture", "answers": ["classification": ["choice": choice, "confidence": confidence], "evidence": ["choice": "0", "confidence": 0.9]]]
    } else if request.url?.path.hasSuffix("/profile") == true {
      body = ["historyId": "100"]
    } else if request.url?.path.hasSuffix("/messages") == true {
      body = ["messages": [["id": "new"]]]
    } else if request.url?.path.hasSuffix("/messages/new") == true {
      body = ["id": "new", "threadId": "new", "labelIds": ["INBOX"], "internalDate": "2000000001000", "snippet": "Invoice June", "payload": ["mimeType": "text/plain", "headers": [["name": "From", "value": "billing@example.com"], ["name": "Subject", "value": "Invoice June"]], "body": ["data": Data("Invoice #2048 amount due 1250".utf8).base64EncodedString()]]]
    } else if request.url?.path.hasSuffix("/labels") == true {
      body = request.httpMethod == "POST" ? ["id": "Label_1", "name": "Finance / Invoices", "type": "user"] : ["labels": []]
    } else if request.url?.path.hasSuffix("/modify") == true && failModify {
      status = 503; body = ["error": ["message": "Temporarily unavailable"]]
    }
    return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
  }
}
