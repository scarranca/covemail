import AppKit
import CoveCore
import SwiftUI
import XCTest
@testable import Cove

@MainActor final class AssistantTaskTests: XCTestCase {
  private func route(_ json: String, mails: [Mail] = []) async throws -> AssistantCalendar.Result {
    try await AssistantCalendar(complete: { _ in json }, calendar: { _, _ in [] }, calendarAvailable: false,
                                timeZone: TimeZone(identifier: "America/Mexico_City")!)
      .respond("create a task so I can address this and remove this", mails: mails, progress: { _ in })
  }

  func testTaskRoutesToAReviewCardLinkedToTheSelectedEmail() async throws {
    let selected = Mail(id: "m1", sender: "GitHub", senderEmail: "noreply@github.com", subject: "Sync MCP Metrics failed", body: "Run failed")
    guard case .task(let task) = try await route(
      #"{"action":"task","title":"Fix the Sync MCP Metrics failure","due":"2026-10-02","archive":true}"#, mails: [selected])
    else { return XCTFail("a task request must not become a calendar question") }
    XCTAssertEqual(task.title, "Fix the Sync MCP Metrics failure")
    XCTAssertEqual(task.mailID, "m1")
    XCTAssertTrue(task.archive)
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Mexico_City")!
    XCTAssertEqual(task.due.map { calendar.dateComponents([.year, .month, .day], from: $0) }, DateComponents(year: 2026, month: 10, day: 2))
  }

  func testArchiveNeedsASelectedEmailAndATitle() async throws {
    guard case .task(let task) = try await route(#"{"action":"task","title":"Call the bank","archive":true}"#) else { return XCTFail() }
    XCTAssertNil(task.mailID)
    XCTAssertFalse(task.archive, "with nothing on screen there is no email to archive")
    XCTAssertNil(task.due)
    guard case .clarification = try await route(#"{"action":"task","title":"  "}"#) else { return XCTFail("an empty task asks") }
  }

  func testRouterPromptOffersTasksAndTreatsRemoveAsArchive() {
    let prompt = AIIntent.planAssistant.instructions
    XCTAssertTrue(prompt.contains(#"{"action":"task""#))
    XCTAssertTrue(prompt.contains("means archiving it"))
    XCTAssertTrue(prompt.contains("never ask for a time or duration for a task"))
  }

  func testTaskCardRenders() throws {
    let mail = Mail(id: "m1", sender: "GitHub", senderEmail: "noreply@github.com", subject: "[covemail] Sync MCP Metrics workflow run failed", body: "")
    let proposal = AssistantCalendar.TaskProposal(title: "Fix the Sync MCP Metrics failure", due: Date(timeIntervalSince1970: 1_790_900_000),
                                                  notes: "", mailID: "m1", archive: true)
    var created = AssistantTaskState(proposal: proposal)
    created.phase = .created(GoogleTask(id: "t", title: proposal.title))
    created.archived = true
    let view = VStack(alignment: .leading, spacing: 16) {
      AssistantTaskCard(state: AssistantTaskState(proposal: proposal), mail: mail, connected: true, connecting: false,
        edit: { _ in }, toggleArchive: { _ in }, connect: {}, add: {}, dismiss: {}, undoArchive: {}, open: {})
      AssistantTaskCard(state: AssistantTaskState(proposal: proposal), mail: mail, connected: false, connecting: false,
        edit: { _ in }, toggleArchive: { _ in }, connect: {}, add: {}, dismiss: {}, undoArchive: {}, open: {})
      AssistantTaskCard(state: created, mail: mail, connected: true, connecting: false,
        edit: { _ in }, toggleArchive: { _ in }, connect: {}, add: {}, dismiss: {}, undoArchive: {}, open: {})
    }.padding(24).frame(width: 600).background(Color.white)
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: 600, height: host.fittingSize.height)
    host.layoutSubtreeIfNeeded()
    let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/tmp/cove-assistant-task-card.png"))
  }
}
